-- SceneKit.Model (model.* operations) on real @lune/roblox instances: inspect, scale, pivot,
-- material, collision, optimize, apply/revert, selection scope, dry runs and the ChangeHistory
-- recording (through an injected recorder, since Lune has no ChangeHistoryService).
local roblox = require("@lune/roblox")
local SK = require("../packages/SceneKit/SceneKit")

local Instance, Vector3, CFrame = roblox.Instance, roblox.Vector3, roblox.CFrame

local cases = {}
local function test(name, fn)
	table.insert(cases, { name = name, fn = fn })
end

-- Stand-in for ChangeHistoryService that records the calls Apply.withUndo makes.
local function recorder()
	local calls = {}
	return {
		calls = calls,
		TryBeginRecording = function(_, name)
			table.insert(calls, "begin:" .. name)
			return "rec"
		end,
		FinishRecording = function(_, id, operation)
			table.insert(calls, "finish:" .. id .. ":" .. operation.Name)
		end,
	}
end

local function part(parent, name: string, size, cf, props: { [string]: any }?)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Anchored = true
	for key, value in props or {} do
		(p :: any)[key] = value
	end
	p.Parent = parent
	return p
end

local function nearV(t, v, x: number, y: number, z: number, label: string)
	t.near(v.X, x, 1e-4, label .. ".X")
	t.near(v.Y, y, 1e-4, label .. ".Y")
	t.near(v.Z, z, 1e-4, label .. ".Z")
end

-- Workspace.Crate: anchored slate base, an unanchored wooden bar turned 90 degrees, an invisible
-- collidable ghost, a MeshPart, and a PointLight on the base.
local function crate()
	local ws = Instance.new("DataModel"):GetService("Workspace")
	local model = Instance.new("Model")
	model.Name = "Crate"
	model.Parent = ws
	local base = part(model, "Base", Vector3.new(4, 1, 4), CFrame.new(10, 0.5, 0), {
		Material = roblox.Enum.Material.Slate,
	})
	local bar = part(
		model,
		"Bar",
		Vector3.new(6, 1, 1),
		CFrame.new(10, 1.5, 0) * CFrame.fromOrientation(0, math.rad(90), 0),
		{ Anchored = false, Material = roblox.Enum.Material.Wood }
	)
	part(model, "Ghost", Vector3.new(1, 1, 1), CFrame.new(12, 0.5, 0), { Transparency = 1 })
	local mesh = Instance.new("MeshPart")
	mesh.Name = "Mesh"
	mesh.Size = Vector3.new(1, 1, 1)
	mesh.CFrame = CFrame.new(8, 0.5, 0)
	mesh.Anchored = true
	mesh.Parent = model
	Instance.new("PointLight").Parent = base
	return ws, model, base, bar, mesh
end

test("Model.inspect: bounds, counts, materials, pivot offset and warnings", function(t)
	local _, model, base, bar = crate()
	model.WorldPivot = CFrame.new(10, 1, 0)
	local report = SK.Model.inspect(model)
	t.eq(report.parts, 4)
	t.eq(report.meshes, 1)
	t.eq(report.lights, 1)
	t.eq(report.classes, { Part = 3, MeshPart = 1 })
	t.eq(report.materials, { Slate = 1, Wood = 1, Plastic = 2 })
	t.eq(report.anchored, 3)
	t.eq(report.unanchored, 1)
	-- Bar is 6 long along X before the 90 degree yaw, so it spans z -3..3; mesh and ghost set x.
	t.eq(report.bounds.min, { x = 7.5, y = 0, z = -3 })
	t.eq(report.bounds.max, { x = 12.5, y = 2, z = 3 })
	t.eq(report.bounds.size, { x = 5, y = 2, z = 6 })
	t.eq(report.bounds.baseCenter, { x = 10, y = 0, z = 0 })
	t.eq(report.pivot.offsetFromBase, { x = 0, y = 1, z = 0 })
	local text = table.concat(report.warnings, "\n")
	t.ok(string.find(text, "Crate.Bar: unanchored and not jointed", 1, true), text)
	t.ok(string.find(text, "Crate.Ghost: invisible but collidable", 1, true), text)
	-- Welding the bar to the base removes the unanchored warning.
	local weld = Instance.new("WeldConstraint")
	weld.Part0, weld.Part1 = base, bar
	weld.Parent = base
	local welded = table.concat(SK.Model.inspect(model).warnings, "\n")
	t.ok(not string.find(welded, "Bar", 1, true), "welded bar still warned: " .. welded)
	-- A list scope dedupes parts reached twice and reports no single pivot.
	local both = SK.Model.inspect({ model, base })
	t.eq(both.parts, 4)
	t.eq(both.pivot, nil)
end)

test("Model scope: selection is empty under Lune, bad scopes error", function(t)
	t.eq(SK.Model.selection(), {})
	local empty = SK.Model.inspect(SK.Model.selection())
	t.eq(empty.parts, 0)
	t.eq(empty.bounds, nil)
	t.eq(SK.Model.scale(SK.Model.selection(), 2).count, 0)
	t.throws(function()
		SK.Model.inspect(42)
	end, "a number is not a scope")
	t.throws(function()
		SK.Model.inspect({ Instance.new("Part"), "Crate" })
	end, "a list with a string is not a scope")
	t.throws(function()
		SK.Model.inspect(nil)
	end, "nil is not a scope")
end)

test("Model.scale: about the pivot, dry run first, one recording, revert restores", function(t)
	local ws = Instance.new("DataModel"):GetService("Workspace")
	local model = Instance.new("Model")
	model.Name = "Kit"
	model.Parent = ws
	model.WorldPivot = CFrame.new(0, 0, 0)
	local a = part(model, "A", Vector3.new(2, 2, 2), CFrame.new(4, 1, 0))
	local turned = CFrame.new(-2, 2, 2) * CFrame.fromOrientation(0, math.rad(30), 0)
	local b = part(model, "B", Vector3.new(1, 4, 1), turned)
	local attachment = Instance.new("Attachment")
	attachment.CFrame = CFrame.new(0, 1, 0)
	attachment.Parent = a
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = roblox.Enum.MeshType.FileMesh
	mesh.Scale = Vector3.new(1, 1, 1)
	mesh.Parent = b

	local dry = SK.Model.scale(model, 2, { dryRun = true, env = roblox })
	t.ok(dry.dryRun and dry.count == 6, "dry run plans 6 changes, got " .. dry.count)
	nearV(t, a.Size, 2, 2, 2, "dry run leaves A.Size")
	nearV(t, a.CFrame.Position, 4, 1, 0, "dry run leaves A position")
	t.eq(dry.changes[1].path, "Workspace.Kit.A")
	t.eq(dry.changes[1].property, "Size")
	t.eq(dry.changes[1].to, { x = 4, y = 4, z = 4 })

	local history = recorder()
	local result = SK.Model.scale(model, 2, { env = roblox, history = history })
	t.eq(history.calls, { "begin:SceneKit Model.scale", "finish:rec:Commit" })
	nearV(t, a.Size, 4, 4, 4, "A.Size")
	nearV(t, a.CFrame.Position, 8, 2, 0, "A position doubles from the pivot")
	nearV(t, b.CFrame.Position, -4, 4, 4, "B position")
	t.near(select(2, b.CFrame:ToOrientation()), math.rad(30), 1e-6, "B keeps its yaw")
	nearV(t, attachment.CFrame.Position, 0, 2, 0, "attachment offset")
	nearV(t, mesh.Scale, 2, 2, 2, "FileMesh scale")
	nearV(t, model.WorldPivot.Position, 0, 0, 0, "pivot stays put")
	t.eq(SK.Model.inspect(model).bounds.min.y, 0, "base stays on the pivot plane")

	SK.Model.revert(result, { env = roblox })
	nearV(t, a.Size, 2, 2, 2, "revert A.Size")
	nearV(t, a.CFrame.Position, 4, 1, 0, "revert A position")
	nearV(t, b.CFrame.Position, -2, 2, 2, "revert B position")
	nearV(t, attachment.CFrame.Position, 0, 1, 0, "revert attachment")

	-- Explicit centre; a list scope without one uses the base centre of its bounds.
	SK.Model.scale(a, 0.5, { env = roblox, about = { x = 4, y = 0, z = 0 } })
	nearV(t, a.CFrame.Position, 4, 0.5, 0, "scaled about its own foot")
	-- Joint offsets are not scaled: warned.
	local weld = Instance.new("WeldConstraint")
	weld.Part0, weld.Part1 = a, b
	weld.Parent = a
	local warned = SK.Model.scale(model, 1.5, { env = roblox, dryRun = true })
	t.ok(string.find(warned.warnings[1] or "", "jointed parts", 1, true), "jointed warning")
	-- Failure cases: bad factors and dry-run revert.
	for _, factor in { 0, -1, 0 / 0, math.huge } do
		t.throws(function()
			SK.Model.scale(model, factor, { env = roblox })
		end, "factor " .. tostring(factor) .. " must error")
	end
	t.throws(function()
		SK.Model.revert(dry)
	end, "a dry run cannot be reverted")
end)

test("Model.pivot: base_center, center and CFrame for models, primary parts and parts", function(t)
	local _, model, base = crate()
	SK.Model.pivot(model, "base_center", { env = roblox })
	nearV(t, model.WorldPivot.Position, 10, 0, 0, "WorldPivot at the base centre")
	t.eq(SK.Model.inspect(model).pivot.offsetFromBase, { x = 0, y = 0, z = 0 })
	SK.Model.pivot(model, "center", { env = roblox })
	nearV(t, model.WorldPivot.Position, 10, 1, 0, "WorldPivot at the centre")

	-- With a PrimaryPart the pivot lives in its PivotOffset.
	local _, primary, primaryBase = crate()
	primary.PrimaryPart = primaryBase
	local result = SK.Model.pivot(primary, "base_center", { env = roblox })
	t.eq(result.changes[1].property, "PivotOffset")
	nearV(t, SK.Model.pivotOf(primary).Position, 10, 0, 0, "primary-part pivot at the base centre")

	-- A part: PivotOffset relative to its own CFrame.
	local target = CFrame.new(11, 0, 1)
	SK.Model.pivot(base, target, { env = roblox })
	nearV(t, (base.CFrame * base.PivotOffset).Position, 11, 0, 1, "part pivot")

	-- Dry run does not move it; folders are skipped with a warning; bad modes error.
	SK.Model.pivot(base, "center", { env = roblox, dryRun = true })
	nearV(t, (base.CFrame * base.PivotOffset).Position, 11, 0, 1, "dry run keeps the pivot")
	local folder = Instance.new("Folder")
	folder.Name = "Loose"
	local skipped = SK.Model.pivot({ folder }, "center", { env = roblox })
	t.eq(skipped.count, 0)
	t.ok(string.find(skipped.warnings[1], "not a Model or BasePart", 1, true))
	t.throws(function()
		SK.Model.pivot(model, "top", { env = roblox })
	end, "unknown pivot mode")
end)

test("Model.material and Model.collision: filters, validation, warnings", function(t)
	local _, model, base, bar, mesh = crate()
	local result = SK.Model.material(
		model,
		{ material = "Concrete", color = { 10, 20, 30 }, filter = { material = "Plastic" }, env = roblox }
	)
	t.eq(result.count, 4, "ghost and mesh: material + colour each")
	t.eq(mesh.Material.Name, "Concrete")
	t.eq(SK.Model.plain(mesh.Color), { 10, 20, 30 })
	t.eq(base.Material.Name, "Slate", "filtered out")
	SK.Model.material(model, {
		material = roblox.Enum.Material.Granite,
		filter = function(p)
			return p.Name == "Bar"
		end,
		env = roblox,
	})
	t.eq(bar.Material.Name, "Granite")
	t.throws(function()
		SK.Model.material(model, { material = "Unobtainium", env = roblox })
	end, "unknown material")
	t.eq(base.Material.Name, "Slate", "nothing changed by the failed call")
	t.throws(function()
		SK.Model.material(model, { env = roblox })
	end, "material or color required")

	local collision = SK.Model.collision(model, {
		canCollide = false,
		canQuery = false,
		canTouch = false,
		collisionGroup = "SETUP_ONLY_Props",
		collisionFidelity = "Box",
		env = roblox,
	})
	for _, p in { base, bar, mesh } do
		t.ok(not p.CanCollide and not p.CanQuery and not p.CanTouch, p.Name .. " collision off")
		t.eq(p.CollisionGroup, "SETUP_ONLY_Props")
	end
	t.eq(mesh.CollisionFidelity.Name, "Box")
	t.ok(string.find(collision.warnings[1], "3 parts are not MeshParts", 1, true), collision.warnings[1])
	local ignored =
		SK.Model.collision(base, { canCollide = true, canQuery = false, env = roblox, dryRun = true })
	t.ok(string.find(ignored.warnings[1], "CanQuery = false has no effect", 1, true))
	t.throws(function()
		SK.Model.collision(model, { env = roblox })
	end, "no setting given")
	t.throws(function()
		SK.Model.collision(model, { collisionFidelity = "Exact", env = roblox })
	end, "unknown fidelity")
	t.throws(function()
		SK.Model.collision(model, { collisionGroup = 5 :: any, env = roblox })
	end, "collision group must be a string")
end)

test("Model.apply: a failing set restores earlier changes and cancels the recording", function(t)
	local _, _, base, bar = crate()
	local history = recorder()
	local ok, err = pcall(function()
		SK.Model.apply({
			{ instance = base, property = "CanCollide", to = false },
			{ instance = bar, property = "Transparency", to = 0.5 },
			{ instance = base, property = "CollisionGroup", to = 5 }, -- wrong type: the set errors
		}, { env = roblox, history = history })
	end)
	t.ok(not ok, "the bad set must raise")
	t.ok(err ~= nil)
	t.ok(base.CanCollide, "CanCollide restored")
	t.eq(bar.Transparency, 0, "Transparency restored")
	t.eq(history.calls, { "begin:SceneKit Model.apply", "finish:rec:Cancel" })
	local applied = SK.Model.apply(
		{ { instance = bar, property = "Transparency", to = 0.25 } },
		{ env = roblox }
	)
	t.eq(applied.changes[1].from, 0)
	t.eq(bar.Transparency, 0.25)
	t.throws(function()
		SK.Model.apply({ { instance = "Bar", property = "Transparency", to = 1 } } :: any)
	end, "change without an instance")
end)

test("Model.optimize: reports cheap wins, applies only the safe fixes when asked", function(t)
	local ws = Instance.new("DataModel"):GetService("Workspace")
	local model = Instance.new("Model")
	model.Name = "Yard"
	model.Parent = ws
	local loose = part(model, "Loose", Vector3.new(2, 2, 2), CFrame.new(0, 1, 0), { Anchored = false })
	local pebble = part(model, "Pebble", Vector3.new(0.5, 0.4, 0.5), CFrame.new(3, 0.2, 0))
	local hinged = part(model, "Hinged", Vector3.new(2, 2, 2), CFrame.new(6, 1, 0), { Anchored = false })
	local post = part(model, "Post", Vector3.new(1, 4, 1), CFrame.new(8, 2, 0))
	local weld = Instance.new("WeldConstraint")
	weld.Part0, weld.Part1 = hinged, post
	weld.Parent = post
	part(model, "Barrier", Vector3.new(1, 6, 8), CFrame.new(-4, 3, 0), { Transparency = 1 })

	local report = SK.Model.optimize(model, { partBudget = 3 })
	local kinds = {}
	for _, finding in report.findings do
		kinds[finding.kind] = (kinds[finding.kind] or 0) + 1
	end
	t.eq(kinds, { unanchored_static = 1, tiny_shadow = 1, invisible_collidable = 1, part_budget = 1 })
	t.eq(report.count, 2, "two safe fixes planned")
	t.ok(not report.applied and report.dryRun)
	t.ok(not loose.Anchored, "report only: nothing applied")
	t.ok(SK.Model.optimize(model, { apply = true, dryRun = true }).dryRun, "dryRun wins over apply")
	t.ok(not loose.Anchored)

	local history = recorder()
	local applied = SK.Model.optimize(model, { apply = true, env = roblox, history = history })
	t.ok(applied.applied)
	t.ok(loose.Anchored, "loose part anchored")
	t.ok(not pebble.CastShadow, "tiny part casts no shadow")
	t.ok(not hinged.Anchored, "welded part left alone")
	t.eq(history.calls, { "begin:SceneKit Model.optimize", "finish:rec:Commit" })
	t.eq(SK.Model.optimize(model).count, 0, "nothing left to fix")
end)

test("Apply.scene records one ChangeHistory waypoint and cancels it on error", function(t)
	local ws = Instance.new("DataModel"):GetService("Workspace")
	local scene = SK.Scene.new({ name = "Undo", seed = 1 })
	scene:box("wall", { x = 0, y = 0, z = 0 }, { x = 4, y = 4, z = 1 })
	local history = recorder()
	SK.Apply.scene(scene, ws, { env = roblox, history = history })
	t.eq(history.calls, { "begin:SceneKit Undo", "finish:rec:Commit" })
	local broken = SK.Scene.new({ name = "Broken" })
	broken:box("wall", { x = 0, y = 0, z = 0 }, { x = 4, y = 4, z = 1 }, { material = "NotAMaterial" })
	local failing = recorder()
	t.throws(function()
		SK.Apply.scene(broken, ws, { env = roblox, history = failing })
	end, "unknown material must error")
	t.eq(failing.calls, { "begin:SceneKit Broken", "finish:rec:Cancel" })
	t.eq(ws:FindFirstChild("Broken"), nil, "the failed model is never parented")
end)

return cases
